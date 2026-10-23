/*
====================================================================
  EVALUACION PARCIAL N2 - TALLER DE BASE DE DATOS (BDY1103)
  Caso de negocio : Empresa de mecanizados CNC
  Objetivo        : guardar y buscar por NP (Numero de Proyecto) el
                    plano y las herramientas usadas en cada trabajo,
                    y controlar el stock de herramientas.
  Integrantes     : Franconis Velasquez y Sebastian Yajure

  Ejecutar completo como script (SQL Developer: F5 / Run Script).
  El script se puede correr varias veces: borra y recrea todo.
====================================================================
*/

SET SERVEROUTPUT ON;

-- ====================================================================
-- 0. LIMPIEZA (permite re-ejecutar el script sin errores)
-- ====================================================================
DECLARE
    TYPE t_lista IS TABLE OF VARCHAR2(200);
    v_sql t_lista := t_lista(
        'DROP TRIGGER trg_actualizar_stock',
        'DROP TRIGGER trg_log_uso_sentencia',
        'DROP TRIGGER trg_alerta_stock_minimo',
        'DROP PACKAGE pkg_gestion_cnc',
        'DROP PROCEDURE sp_reponer_stock_critico',
        'DROP FUNCTION fn_cantidad_usada_np',
        'DROP TABLE alerta_stock CASCADE CONSTRAINTS',
        'DROP TABLE log_uso_herramienta CASCADE CONSTRAINTS',
        'DROP TABLE uso_herramienta CASCADE CONSTRAINTS',
        'DROP TABLE proyectos CASCADE CONSTRAINTS',
        'DROP TABLE herramientas CASCADE CONSTRAINTS',
        'DROP TABLE planos CASCADE CONSTRAINTS',
        'DROP SEQUENCE seq_uso_herramienta',
        'DROP SEQUENCE seq_log_uso',
        'DROP SEQUENCE seq_alerta_stock'
    );
BEGIN
    FOR i IN 1 .. v_sql.COUNT LOOP
        BEGIN
            EXECUTE IMMEDIATE v_sql(i);
        EXCEPTION
            WHEN OTHERS THEN NULL;  -- el objeto aun no existe
        END;
    END LOOP;
END;
/

-- ====================================================================
-- 1. TABLAS Y SECUENCIAS
-- ====================================================================

-- Planos: cada proyecto tiene un plano asociado
CREATE TABLE planos (
    id_plano      NUMBER PRIMARY KEY,
    codigo_plano  VARCHAR2(20) NOT NULL,
    descripcion   VARCHAR2(100),
    revision      VARCHAR2(5)
);

-- Herramientas (fresas, brocas, insertos, etc.)
-- El CHECK impide que el stock quede negativo, incluso con INSERT directo
CREATE TABLE herramientas (
    id_herramienta   NUMBER PRIMARY KEY,
    nombre           VARCHAR2(50) NOT NULL,
    tipo             VARCHAR2(30),
    stock_actual     NUMBER DEFAULT 0,
    stock_minimo     NUMBER DEFAULT 5,
    vida_util_max    NUMBER,
    vida_util_usada  NUMBER DEFAULT 0,
    CONSTRAINT ck_stock_no_negativo CHECK (stock_actual >= 0)
);

-- Proyectos, identificados por NP
CREATE TABLE proyectos (
    np             NUMBER PRIMARY KEY,
    cliente        VARCHAR2(50),
    id_plano       NUMBER REFERENCES planos(id_plano),
    fecha_inicio   DATE,
    fecha_termino  DATE,
    estado         VARCHAR2(15)
);

-- Herramientas usadas en cada proyecto (se consulta por NP)
CREATE TABLE uso_herramienta (
    id_uso          NUMBER PRIMARY KEY,
    np              NUMBER REFERENCES proyectos(np),
    id_herramienta  NUMBER REFERENCES herramientas(id_herramienta),
    cantidad        NUMBER NOT NULL CHECK (cantidad > 0),
    fecha_uso       DATE DEFAULT SYSDATE
);

-- Bitacora de operaciones sobre uso_herramienta (la llena el trigger de sentencia)
CREATE TABLE log_uso_herramienta (
    id_log   NUMBER PRIMARY KEY,
    fecha    DATE DEFAULT SYSDATE,
    usuario  VARCHAR2(30),
    accion   VARCHAR2(10)
);

-- Alertas de stock bajo (la llena el trigger de fila sobre herramientas)
CREATE TABLE alerta_stock (
    id_alerta       NUMBER PRIMARY KEY,
    id_herramienta  NUMBER,
    fecha           DATE DEFAULT SYSDATE,
    stock_actual    NUMBER,
    stock_minimo    NUMBER,
    mensaje         VARCHAR2(120)
);

-- Secuencias: generan IDs unicos y consecutivos
CREATE SEQUENCE seq_uso_herramienta START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE seq_log_uso         START WITH 1 INCREMENT BY 1;
CREATE SEQUENCE seq_alerta_stock    START WITH 1 INCREMENT BY 1;

-- ====================================================================
-- 2. FUNCION Y PROCEDIMIENTO ALMACENADOS INDEPENDIENTES
--    (fuera del package, para mostrar su uso por separado)
-- ====================================================================

-- Funcion CON parametro: total de unidades de herramientas usadas en un NP.
-- Solo lee datos, por eso se puede llamar desde un SELECT.
CREATE OR REPLACE FUNCTION fn_cantidad_usada_np(p_np IN NUMBER)
    RETURN NUMBER
IS
    v_total NUMBER;
BEGIN
    SELECT NVL(SUM(cantidad), 0)
    INTO   v_total
    FROM   uso_herramienta
    WHERE  np = p_np;

    RETURN v_total;
END fn_cantidad_usada_np;
/

-- Procedimiento SIN parametros, procesamiento masivo:
-- repone el stock de TODAS las herramientas que estan en o bajo el minimo.
-- No hace COMMIT: lo confirma quien lo llama.
CREATE OR REPLACE PROCEDURE sp_reponer_stock_critico
IS
BEGIN
    UPDATE herramientas
    SET    stock_actual = stock_minimo * 4
    WHERE  stock_actual <= stock_minimo;

    DBMS_OUTPUT.PUT_LINE('Herramientas repuestas: ' || SQL%ROWCOUNT);
END sp_reponer_stock_critico;
/

-- ====================================================================
-- 3. PACKAGE pkg_gestion_cnc
--    La especificacion declara lo PUBLICO. Lo que solo aparece en el
--    body (excepcion, variable, funcion y procedimiento auxiliares)
--    es PRIVADO.
-- ====================================================================
CREATE OR REPLACE PACKAGE pkg_gestion_cnc AS

    -- VARRAY: lista de hasta 15 nombres de herramientas
    TYPE t_herramientas_arr IS VARRAY(15) OF VARCHAR2(50);

    -- RECORD: agrupa los datos de un trabajo completo
    TYPE t_trabajo_rec IS RECORD (
        v_np           proyectos.np%TYPE,
        v_cliente      proyectos.cliente%TYPE,
        v_cod_plano    planos.codigo_plano%TYPE,
        v_desc_plano   planos.descripcion%TYPE,
        v_herramientas t_herramientas_arr
    );

    -- PROCEDIMIENTO CON parametros: valida y registra el uso de una herramienta
    PROCEDURE sp_registrar_uso_herramienta(
        p_np             IN proyectos.np%TYPE,
        p_id_herramienta IN herramientas.id_herramienta%TYPE,
        p_cantidad       IN NUMBER
    );

    -- PROCEDIMIENTO CON parametro: muestra plano + herramientas de un NP
    PROCEDURE sp_buscar_trabajo(p_np IN proyectos.np%TYPE);

    -- PROCEDIMIENTO SIN parametros (masivo): lista todas las herramientas en stock critico
    PROCEDURE sp_reporte_stock_critico;

    -- FUNCION CON parametro: stock disponible de una herramienta
    FUNCTION fn_stock_disponible(p_id_herramienta IN herramientas.id_herramienta%TYPE)
        RETURN NUMBER;

    -- FUNCION SIN parametros: cuantas herramientas estan en o bajo el stock minimo
    FUNCTION fn_total_herramientas_criticas RETURN NUMBER;

END pkg_gestion_cnc;
/

CREATE OR REPLACE PACKAGE BODY pkg_gestion_cnc AS

    -- ---------------- ELEMENTOS PRIVADOS ----------------

    -- Excepcion definida por el usuario: se lanza si piden mas de lo que hay en stock
    e_stock_insuficiente EXCEPTION;

    -- Variable privada: se asigna una vez por sesion en el bloque de inicializacion
    g_fecha_carga DATE;

    -- Funcion privada: valida que el NP exista (no se puede llamar desde fuera)
    FUNCTION fn_existe_proyecto(p_np IN proyectos.np%TYPE) RETURN BOOLEAN IS
        v_cont NUMBER;
    BEGIN
        SELECT COUNT(*) INTO v_cont FROM proyectos WHERE np = p_np;
        RETURN v_cont > 0;
    END fn_existe_proyecto;

    -- Procedimiento privado: imprime la linea separadora de los reportes
    PROCEDURE pr_linea IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('=====================================');
    END pr_linea;

    -- ---------------- ELEMENTOS PUBLICOS ----------------

    FUNCTION fn_stock_disponible(p_id_herramienta IN herramientas.id_herramienta%TYPE)
        RETURN NUMBER
    IS
        v_stock NUMBER;
    BEGIN
        SELECT stock_actual
        INTO   v_stock
        FROM   herramientas
        WHERE  id_herramienta = p_id_herramienta;

        RETURN v_stock;
    EXCEPTION
        -- Excepcion predefinida de Oracle: salta sola si no hay filas
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20002, 'No existe la herramienta indicada.');
    END fn_stock_disponible;


    FUNCTION fn_total_herramientas_criticas RETURN NUMBER IS
        v_total NUMBER;
    BEGIN
        SELECT COUNT(*)
        INTO   v_total
        FROM   herramientas
        WHERE  stock_actual <= stock_minimo;

        RETURN v_total;
    END fn_total_herramientas_criticas;


    PROCEDURE sp_registrar_uso_herramienta(
        p_np             IN proyectos.np%TYPE,
        p_id_herramienta IN herramientas.id_herramienta%TYPE,
        p_cantidad       IN NUMBER
    ) IS
        v_stock_actual NUMBER;
    BEGIN
        IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
            RAISE_APPLICATION_ERROR(-20005, 'La cantidad debe ser mayor a cero.');
        END IF;

        IF NOT fn_existe_proyecto(p_np) THEN
            RAISE_APPLICATION_ERROR(-20004, 'El proyecto NP ' || p_np || ' no existe.');
        END IF;

        -- Si la herramienta no existe, la funcion lanza el error -20002
        v_stock_actual := fn_stock_disponible(p_id_herramienta);

        IF v_stock_actual < p_cantidad THEN
            RAISE e_stock_insuficiente;
        END IF;

        -- El INSERT dispara los triggers (descuento de stock y bitacora)
        INSERT INTO uso_herramienta (id_uso, np, id_herramienta, cantidad, fecha_uso)
        VALUES (seq_uso_herramienta.NEXTVAL, p_np, p_id_herramienta, p_cantidad, SYSDATE);

        -- Sin COMMIT: lo confirma quien llama, asi un proceso masivo puede hacer ROLLBACK

    EXCEPTION
        WHEN e_stock_insuficiente THEN
            RAISE_APPLICATION_ERROR(-20003,
                'No hay stock suficiente de la herramienta ' || p_id_herramienta ||
                '. Disponible: ' || v_stock_actual || ', pedido: ' || p_cantidad);
    END sp_registrar_uso_herramienta;


    PROCEDURE sp_buscar_trabajo(p_np IN proyectos.np%TYPE) IS

        v_trabajo  t_trabajo_rec;
        v_omitidas NUMBER := 0;

        -- Cursor explicito CON parametro: herramientas usadas en ESE proyecto
        CURSOR c_herramientas_uso(pr_np NUMBER) IS
            SELECT h.nombre
            FROM   uso_herramienta u
            JOIN   herramientas h ON h.id_herramienta = u.id_herramienta
            WHERE  u.np = pr_np
            ORDER  BY u.id_uso;

    BEGIN
        -- El VARRAY hay que inicializarlo antes de usarlo
        v_trabajo.v_herramientas := t_herramientas_arr();

        -- SELECT INTO: datos del proyecto y su plano
        SELECT p.np, p.cliente, pl.codigo_plano, pl.descripcion
        INTO   v_trabajo.v_np, v_trabajo.v_cliente,
               v_trabajo.v_cod_plano, v_trabajo.v_desc_plano
        FROM   proyectos p
        JOIN   planos pl ON pl.id_plano = p.id_plano
        WHERE  p.np = p_np;

        -- Loop sobre el cursor: llena el VARRAY (con tope para no pasar el limite de 15)
        FOR fila IN c_herramientas_uso(p_np) LOOP
            IF v_trabajo.v_herramientas.COUNT < v_trabajo.v_herramientas.LIMIT THEN
                v_trabajo.v_herramientas.EXTEND;
                v_trabajo.v_herramientas(v_trabajo.v_herramientas.COUNT) := fila.nombre;
            ELSE
                v_omitidas := v_omitidas + 1;
            END IF;
        END LOOP;

        pr_linea;
        DBMS_OUTPUT.PUT_LINE('NP: ' || v_trabajo.v_np || '  Cliente: ' || v_trabajo.v_cliente);
        DBMS_OUTPUT.PUT_LINE('Plano: ' || v_trabajo.v_cod_plano || ' - ' || v_trabajo.v_desc_plano);

        IF v_trabajo.v_herramientas.COUNT = 0 THEN
            DBMS_OUTPUT.PUT_LINE('No hay herramientas registradas para este proyecto.');
        ELSE
            -- Loop anidado en el flujo: recorre el VARRAY ya lleno
            FOR i IN 1 .. v_trabajo.v_herramientas.COUNT LOOP
                DBMS_OUTPUT.PUT_LINE('- Herramienta usada: ' || v_trabajo.v_herramientas(i));
            END LOOP;
            IF v_omitidas > 0 THEN
                DBMS_OUTPUT.PUT_LINE('(' || v_omitidas || ' registros mas no se muestran: limite de 15)');
            END IF;
        END IF;
        pr_linea;

    EXCEPTION
        -- Excepcion predefinida: el NP no existe
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 'El proyecto NP ' || p_np || ' no existe.');
    END sp_buscar_trabajo;


    PROCEDURE sp_reporte_stock_critico IS
        -- Cursor explicito SIN parametros: recorre todas las herramientas en stock critico
        CURSOR c_criticas IS
            SELECT nombre, stock_actual, stock_minimo
            FROM   herramientas
            WHERE  stock_actual <= stock_minimo
            ORDER  BY nombre;
    BEGIN
        pr_linea;
        DBMS_OUTPUT.PUT_LINE('REPORTE DE STOCK CRITICO (' ||
                             TO_CHAR(SYSDATE, 'DD-MM-YYYY HH24:MI') || ')');
        DBMS_OUTPUT.PUT_LINE('Package cargado en esta sesion: ' ||
                             TO_CHAR(g_fecha_carga, 'DD-MM-YYYY HH24:MI:SS'));

        FOR r IN c_criticas LOOP
            DBMS_OUTPUT.PUT_LINE('- ' || r.nombre || ' | stock: ' || r.stock_actual ||
                                 ' | minimo: ' || r.stock_minimo);
        END LOOP;

        DBMS_OUTPUT.PUT_LINE('Total herramientas criticas: ' || fn_total_herramientas_criticas);
        pr_linea;
    END sp_reporte_stock_critico;

-- Bloque de inicializacion del package: se ejecuta una vez por sesion
BEGIN
    g_fecha_carga := SYSDATE;
END pkg_gestion_cnc;
/

-- ====================================================================
-- 4. TRIGGERS
-- ====================================================================

-- TRIGGER A NIVEL DE FILA (FOR EACH ROW): por cada registro de uso insertado,
-- descuenta el stock y suma la vida util usada de esa herramienta.
CREATE OR REPLACE TRIGGER trg_actualizar_stock
AFTER INSERT ON uso_herramienta
FOR EACH ROW
BEGIN
    UPDATE herramientas
    SET    stock_actual    = stock_actual - :NEW.cantidad,
           vida_util_usada = vida_util_usada + :NEW.cantidad
    WHERE  id_herramienta  = :NEW.id_herramienta;
END trg_actualizar_stock;
/

-- TRIGGER A NIVEL DE SENTENCIA (sin FOR EACH ROW): se dispara UNA sola vez por
-- sentencia INSERT/UPDATE/DELETE, sin importar cuantas filas afecte.
CREATE OR REPLACE TRIGGER trg_log_uso_sentencia
AFTER INSERT OR UPDATE OR DELETE ON uso_herramienta
DECLARE
    v_accion VARCHAR2(10);
BEGIN
    IF INSERTING THEN
        v_accion := 'INSERT';
    ELSIF UPDATING THEN
        v_accion := 'UPDATE';
    ELSE
        v_accion := 'DELETE';
    END IF;

    INSERT INTO log_uso_herramienta (id_log, fecha, usuario, accion)
    VALUES (seq_log_uso.NEXTVAL, SYSDATE, USER, v_accion);
END trg_log_uso_sentencia;
/

-- TRIGGER A NIVEL DE FILA sobre herramientas: genera una alerta cuando el stock
-- de una herramienta baja del minimo.
CREATE OR REPLACE TRIGGER trg_alerta_stock_minimo
AFTER UPDATE OF stock_actual ON herramientas
FOR EACH ROW
WHEN (NEW.stock_actual <= NEW.stock_minimo)
BEGIN
    INSERT INTO alerta_stock (id_alerta, id_herramienta, fecha, stock_actual, stock_minimo, mensaje)
    VALUES (seq_alerta_stock.NEXTVAL, :NEW.id_herramienta, SYSDATE,
            :NEW.stock_actual, :NEW.stock_minimo,
            'Stock bajo el minimo: ' || :NEW.nombre);
END trg_alerta_stock_minimo;
/

-- ====================================================================
-- 5. DATOS DE PRUEBA
-- ====================================================================
INSERT INTO planos (id_plano, codigo_plano, descripcion, revision)
VALUES (1, 'PL-001', 'Brida de acero inoxidable', 'A');
INSERT INTO planos (id_plano, codigo_plano, descripcion, revision)
VALUES (2, 'PL-002', 'Eje escalonado 45mm', 'B');
INSERT INTO planos (id_plano, codigo_plano, descripcion, revision)
VALUES (3, 'PL-003', 'Soporte para rodamiento', 'A');

INSERT INTO herramientas (id_herramienta, nombre, tipo, stock_actual, stock_minimo, vida_util_max, vida_util_usada)
VALUES (1, 'Fresa de 10mm', 'Fresa', 20, 5, 100, 0);
INSERT INTO herramientas (id_herramienta, nombre, tipo, stock_actual, stock_minimo, vida_util_max, vida_util_usada)
VALUES (2, 'Broca de 8mm', 'Broca', 15, 5, 80, 0);
INSERT INTO herramientas (id_herramienta, nombre, tipo, stock_actual, stock_minimo, vida_util_max, vida_util_usada)
VALUES (3, 'Inserto CNMG 120408', 'Inserto', 10, 3, 50, 0);
INSERT INTO herramientas (id_herramienta, nombre, tipo, stock_actual, stock_minimo, vida_util_max, vida_util_usada)
VALUES (4, 'Fresa de 6mm', 'Fresa', 12, 5, 90, 0);
INSERT INTO herramientas (id_herramienta, nombre, tipo, stock_actual, stock_minimo, vida_util_max, vida_util_usada)
VALUES (5, 'Broca de 12mm', 'Broca', 8, 3, 70, 0);

INSERT INTO proyectos (np, cliente, id_plano, fecha_inicio, fecha_termino, estado)
VALUES (1001, 'Metalurgica Andes', 1, DATE '2026-08-01', DATE '2026-08-05', 'TERMINADO');
INSERT INTO proyectos (np, cliente, id_plano, fecha_inicio, fecha_termino, estado)
VALUES (1002, 'Industrias del Sur', 2, DATE '2026-08-10', NULL, 'EN_CURSO');
INSERT INTO proyectos (np, cliente, id_plano, fecha_inicio, fecha_termino, estado)
VALUES (1003, 'Talleres Norte', 3, DATE '2026-08-12', DATE '2026-08-14', 'TERMINADO');

COMMIT;

-- ====================================================================
-- 6. PRUEBAS
-- ====================================================================

PROMPT ===== PRUEBA 1: registrar uso de herramientas (procedimiento con parametros) =====
BEGIN
    pkg_gestion_cnc.sp_registrar_uso_herramienta(1001, 1, 2);
    pkg_gestion_cnc.sp_registrar_uso_herramienta(1001, 3, 4);
    pkg_gestion_cnc.sp_registrar_uso_herramienta(1002, 2, 1);
    pkg_gestion_cnc.sp_registrar_uso_herramienta(1003, 4, 3);
    pkg_gestion_cnc.sp_registrar_uso_herramienta(1003, 5, 2);
    COMMIT;
END;
/

PROMPT ===== PRUEBA 2: buscar trabajos por NP (plano + herramientas) =====
BEGIN
    pkg_gestion_cnc.sp_buscar_trabajo(1001);
    pkg_gestion_cnc.sp_buscar_trabajo(1003);
END;
/

PROMPT ===== PRUEBA 3: excepciones controladas =====
BEGIN
    pkg_gestion_cnc.sp_registrar_uso_herramienta(1002, 3, 999);  -- stock insuficiente
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/
BEGIN
    pkg_gestion_cnc.sp_buscar_trabajo(9999);                     -- NP inexistente
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/
BEGIN
    pkg_gestion_cnc.sp_registrar_uso_herramienta(9999, 1, 1);    -- NP inexistente al registrar
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/
BEGIN
    pkg_gestion_cnc.sp_registrar_uso_herramienta(1002, 99, 1);   -- herramienta inexistente
EXCEPTION
    WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('Error esperado: ' || SQLERRM);
END;
/

PROMPT ===== PRUEBA 4: funciones usadas desde sentencias SQL =====
-- Funcion del package CON parametro, dentro de un SELECT
SELECT id_herramienta,
       nombre,
       pkg_gestion_cnc.fn_stock_disponible(id_herramienta) AS stock_disponible
FROM   herramientas
ORDER  BY id_herramienta;

-- Funcion del package SIN parametros
SELECT pkg_gestion_cnc.fn_total_herramientas_criticas AS herramientas_criticas
FROM   dual;

-- Funcion independiente CON parametro, aplicada a todos los proyectos (masivo)
SELECT np, cliente, fn_cantidad_usada_np(np) AS unidades_usadas
FROM   proyectos
ORDER  BY np;

PROMPT ===== PRUEBA 5: triggers de fila y de sentencia =====
-- Un solo INSERT que afecta 2 filas: el trigger de FILA se ejecuta 2 veces
-- y el de SENTENCIA una sola vez.
INSERT INTO uso_herramienta (id_uso, np, id_herramienta, cantidad)
SELECT seq_uso_herramienta.NEXTVAL, 1002, id_herramienta, 1
FROM   herramientas
WHERE  id_herramienta IN (1, 4);
COMMIT;

SELECT id_herramienta, nombre, stock_actual, vida_util_usada
FROM   herramientas
ORDER  BY id_herramienta;

SELECT * FROM log_uso_herramienta ORDER BY id_log;

PROMPT ===== PRUEBA 6: stock critico, alerta y reposicion =====
BEGIN
    pkg_gestion_cnc.sp_registrar_uso_herramienta(1002, 3, 4);  -- deja el inserto bajo el minimo
    COMMIT;
END;
/

SELECT * FROM alerta_stock ORDER BY id_alerta;

BEGIN
    pkg_gestion_cnc.sp_reporte_stock_critico;   -- procedimiento del package SIN parametros
END;
/

BEGIN
    sp_reponer_stock_critico;                   -- procedimiento independiente SIN parametros
    COMMIT;
END;
/

SELECT id_herramienta, nombre, stock_actual, stock_minimo
FROM   herramientas
ORDER  BY id_herramienta;

PROMPT ===== PRUEBA 7: el CHECK protege el stock aunque se salten el package =====
BEGIN
    INSERT INTO uso_herramienta (id_uso, np, id_herramienta, cantidad)
    VALUES (seq_uso_herramienta.NEXTVAL, 1002, 5, 500);
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error esperado (CHECK de stock): ' || SQLERRM);
        ROLLBACK;
END;
/

PROMPT ===== HISTORIAL FINAL DE USO =====
SELECT * FROM uso_herramienta ORDER BY np, id_uso;
